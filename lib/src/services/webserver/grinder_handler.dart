part of '../webserver_service.dart';

class GrinderHandler {
  GrinderHandler({required GrinderController controller})
    : _controller = controller;

  final GrinderController _controller;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/grinder/info', _info);
    app.get('/api/v1/grinder/state', _state);
    app.put(
      '/api/v1/grinder/state/grinding',
      (_) => _operation(_controller.start),
    );
    app.put('/api/v1/grinder/state/idle', (_) => _operation(_controller.stop));
    app.put('/api/v1/grinder/setting', _setting);
    app.put('/api/v1/grinder/rpm', _rpm);
    app.get(
      '/ws/v1/grinder/snapshot',
      admittedWebSocketHandler(_snapshotSocket),
    );
  }

  Response _info(Request _) {
    try {
      final grinder = _controller.connectedGrinder();
      return jsonOk({
        'deviceId': grinder.deviceId,
        'capabilities': grinder.capabilities
            .map((value) => value.name)
            .toList(),
      });
    } on DeviceNotConnectedException {
      return _unavailable();
    }
  }

  Response _state(Request _) {
    try {
      _controller.connectedGrinder();
      final snapshot = _controller.currentSnapshot;
      return snapshot == null ? _unavailable() : jsonOk(snapshot.toJson());
    } on DeviceNotConnectedException {
      return _unavailable();
    }
  }

  Future<Response> _setting(Request request) async {
    final body = await _jsonBody(request);
    if (body == null || body['setting'] is! String) {
      return jsonBadRequest({'error': 'setting must be a string'});
    }
    return _operation(
      () => _controller.setGrindSetting(body['setting'] as String),
    );
  }

  Future<Response> _rpm(Request request) async {
    final body = await _jsonBody(request);
    final rpm = body?['rpm'];
    if (rpm is! int || rpm < 0) {
      return jsonBadRequest({'error': 'rpm must be an integer >= 0'});
    }
    return _operation(() => _controller.setRpm(rpm));
  }

  Future<Map<String, dynamic>?> _jsonBody(Request request) async {
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: smallRequestBodyBytes,
        timeout: smallRequestBodyTimeout,
      );
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on RequestBodyReadException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  Future<Response> _operation(Future<void> Function() operation) async {
    try {
      await operation();
      return jsonOk(null);
    } on DeviceNotConnectedException {
      return _unavailable();
    } on GrinderOperationException catch (error) {
      return jsonError({'error': error.toString(), 'code': error.code});
    } catch (error) {
      return jsonError({'error': error.toString()});
    }
  }

  Response _unavailable() =>
      jsonServiceUnavailable({'error': 'No grinder connected'});

  void _snapshotSocket(WebSocketChannel socket, String? protocol) {
    final snapshotSubscription = _controller.snapshots.listen(
      (snapshot) => socket.sink.add(jsonEncode(snapshot.toJson())),
    );
    socket.stream.listen(
      (_) {},
      onDone: snapshotSubscription.cancel,
      onError: (_, _) => snapshotSubscription.cancel(),
    );
  }
}
