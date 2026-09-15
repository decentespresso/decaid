part of '../webserver_service.dart';

class ScaleHandler {
  final ScaleController _controller;
  final De1Controller _de1Controller;
  final SettingsController _settingsController;
  final AuxiliaryScaleRegistry _auxiliaryScaleRegistry;

  final Logger _log = Logger("Scale handler");

  ScaleHandler({
    required ScaleController controller,
    required De1Controller de1Controller,
    required SettingsController settingsController,
    required AuxiliaryScaleRegistry auxiliaryScaleRegistry,
  }) : _controller = controller,
       _de1Controller = de1Controller,
       _settingsController = settingsController,
       _auxiliaryScaleRegistry = auxiliaryScaleRegistry;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/scale/<command>', (Request request, String command) async {
      if (command != 'info') {
        return jsonNotFound({'error': 'Unknown command: $command'});
      }
      try {
        final scale = _controller.connectedScale();
        if (scale is! DeviceInformationCapable) return jsonOk({});
        final information =
            (scale as DeviceInformationCapable).currentDeviceInformation;
        final firmwareVersion = information?.firmwareVersion;
        final batteryLevel = information?.batteryLevel;
        return jsonOk({
          'firmwareVersion': ?firmwareVersion,
          'batteryLevel': ?batteryLevel,
        });
      } on DeviceNotConnectedException {
        return jsonServiceUnavailable({'error': 'No scale connected'});
      }
    });
    app.put('/api/v1/scale/<command>', (request, command) async {
      switch (command) {
        case 'tare':
          _log.fine("handling api tare command");
          try {
            await _tarePrimary();
          } on _BlockedTareException {
            return jsonBadRequest({
              'details': 'Tare blocked: a shot is in progress',
              'type': 'block_tare_during_shot',
            });
          } catch (e) {
            _log.warning('tare command failed', e);
            return jsonError({
              'error': e.toString(),
              if (e is ScaleOperationException) 'code': e.code,
            });
          }
          return jsonOk(null);
        default:
          return jsonNotFound({'error': 'Unknown command: $command'});
      }
    });
    app.put('/api/v1/scale/timer/<command>', (request, command) async {
      try {
        final scale = _controller.connectedScale();
        switch (command) {
          case 'start':
            _log.fine("handling api timer start command");
            await scale.startTimer();
            return jsonOk(null);
          case 'stop':
            _log.fine("handling api timer stop command");
            await scale.stopTimer();
            return jsonOk(null);
          case 'reset':
            _log.fine("handling api timer reset command");
            await scale.resetTimer();
            return jsonOk(null);
          default:
            return jsonNotFound({'error': 'Unknown command: $command'});
        }
      } catch (e) {
        _log.warning('timer $command command failed', e);
        return jsonError({
          'error': e.toString(),
          if (e is ScaleOperationException) 'code': e.code,
        });
      }
    });
    app.get('/ws/v1/scale/snapshot', admittedWebSocketHandler(_handleSnapshot));
    app.put('/api/v1/scales/<id>/tare', _handleAddressedTare);
    app.get('/ws/v1/scales/<id>/snapshot', _handleAddressedSnapshot);
  }

  Future<Response> _handleAddressedTare(Request request, String rawId) async {
    late final String id;
    try {
      id = decodeOpaquePathComponent(rawId);
    } on FormatException {
      return jsonBadRequest({'error': 'Invalid scale id'});
    }
    final auxiliary = _auxiliaryScaleRegistry.connectionFor(id);
    try {
      if (auxiliary != null) {
        await auxiliary.scale.tare();
        return jsonOk(null);
      }
      final primary = _controller.connectedScale();
      if (primary.deviceId != id) {
        return jsonNotFound({'error': 'Scale not found: $id'});
      }
      await _tarePrimary();
      return jsonOk(null);
    } on DeviceNotConnectedException {
      return jsonNotFound({'error': 'Scale not found: $id'});
    } on _BlockedTareException {
      return jsonBadRequest({
        'details': 'Tare blocked: a shot is in progress',
        'type': 'block_tare_during_shot',
      });
    } catch (e) {
      return jsonError({
        'error': e.toString(),
        if (e is ScaleOperationException) 'code': e.code,
      });
    }
  }

  Future<void> _tarePrimary() async {
    final shotState = _de1Controller.currentShotState.state;
    final shotActive =
        shotState != ShotState.idle && shotState != ShotState.finished;
    final isFullGateway = _settingsController.gatewayMode == GatewayMode.full;
    if (_settingsController.blockTareDuringShot &&
        shotActive &&
        !isFullGateway) {
      throw _BlockedTareException();
    }
    await _controller.tare();
  }

  FutureOr<Response> _handleAddressedSnapshot(Request request) {
    late final String id;
    try {
      id = decodeOpaquePathComponent(request.params['id']!);
    } on FormatException {
      return jsonBadRequest({'error': 'Invalid scale id'});
    }
    return admittedWebSocketHandler(
      (socket, protocol) => _handleIdSnapshot(socket, id),
    )(request);
  }

  Future<void> _handleIdSnapshot(WebSocketChannel socket, String id) async {
    final hasAuxiliary = _auxiliaryScaleRegistry.connectionFor(id) != null;
    final hasPrimary =
        _controller.currentConnectionState == ConnectionState.connected &&
        _controller.lastConnectedDeviceId == id;
    if (!hasAuxiliary && !hasPrimary) {
      socket.sink.add(jsonEncode({'error': 'Scale not found: $id'}));
      await socket.sink.close();
      return;
    }
    StreamSubscription? snapshotSub;
    StreamSubscription? registrySub;
    StreamSubscription? primaryStateSub;
    Object? boundSource;
    Object? bindingToken;
    var closed = false;
    void dispose() {
      if (closed) return;
      closed = true;
      snapshotSub?.cancel();
      snapshotSub = null;
      registrySub?.cancel();
      registrySub = null;
      primaryStateSub?.cancel();
      primaryStateSub = null;
    }

    void send(Object value) {
      if (!closed) socket.sink.add(jsonEncode(value));
    }

    void bind() {
      final auxiliary = _auxiliaryScaleRegistry.connectionFor(id);
      Scale? primaryScale;
      if (auxiliary == null &&
          _controller.currentConnectionState == ConnectionState.connected &&
          _controller.lastConnectedDeviceId == id) {
        try {
          primaryScale = _controller.connectedScale();
        } on DeviceNotConnectedException {
          primaryScale = null;
        }
      }
      final source =
          auxiliary ??
          (primaryScale == null
              ? null
              : (primaryScale, _controller.connectionGeneration));
      if (source == boundSource) return;
      final hadSource = boundSource != null;
      boundSource = source;
      final token = Object();
      bindingToken = token;
      snapshotSub?.cancel();
      snapshotSub = null;
      if (source == null) {
        if (hadSource) send({'status': 'disconnected'});
        return;
      }
      send({'status': 'connected'});
      if (auxiliary != null) {
        snapshotSub = auxiliary.snapshots.listen((snapshot) {
          if (identical(bindingToken, token)) send(snapshot.toJson());
        });
      } else {
        snapshotSub = primaryScale!.currentSnapshot.listen((snapshot) {
          if (identical(bindingToken, token)) send(snapshot.toJson());
        });
      }
    }

    bind();
    registrySub = _auxiliaryScaleRegistry.changes.listen((_) {
      if (!closed) bind();
    });
    primaryStateSub = _controller.connectionState.listen((_) {
      if (!closed) bind();
    });
    socket.stream.listen((_) {}, onDone: dispose, onError: (_, _) => dispose());
  }

  Future<void> _handleSnapshot(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    _log.fine("handling websocket connection");

    StreamSubscription<WeightSnapshot>? snapshotSub;

    void sendStatus(String status) {
      try {
        socket.sink.add(jsonEncode({'status': status}));
      } catch (_) {}
    }

    void attachSnapshots() {
      snapshotSub?.cancel();
      snapshotSub = null;
      try {
        _controller.connectedScale();
      } catch (e) {
        _log.warning('connected state reported but no scale: $e');
        return;
      }
      snapshotSub = _controller.weightSnapshot.listen((snapshot) {
        try {
          socket.sink.add(jsonEncode(snapshot.toJson()));
        } catch (e, st) {
          _log.severe("failed to send: ", e, st);
        }
      });
    }

    final connSub = _controller.connectionState.listen((state) {
      if (state == ConnectionState.connected) {
        sendStatus('connected');
        attachSnapshots();
      } else {
        snapshotSub?.cancel();
        snapshotSub = null;
        sendStatus('disconnected');
      }
    });

    socket.stream.listen(
      (e) {},
      onDone: () {
        connSub.cancel();
        snapshotSub?.cancel();
      },
      onError: (e, st) {
        connSub.cancel();
        snapshotSub?.cancel();
      },
    );
  }
}

class _BlockedTareException implements Exception {}
