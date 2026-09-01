part of '../webserver_service.dart';

class GrinderHandler {
  final GrinderController _controller;

  final Logger _log = Logger("Grinder handler");

  GrinderHandler({required GrinderController controller})
      : _controller = controller;

  StreamSubscription<GrinderSnapshot>? snapshotSub;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/grinder', (request) async {
      final snapshot = _controller.latestSnapshot;
      if (snapshot == null) {
        return jsonOk({
          'connected': _controller.currentConnectionState ==
              ConnectionState.connected,
          'snapshot': null,
        });
      }
      return jsonOk({
        'connected': _controller.currentConnectionState ==
            ConnectionState.connected,
        'snapshot': snapshot.toJson(),
      });
    });

    app.put('/api/v1/grinder/settings', (request) async {
      final grinder = _controller.connectedGrinder();
      final payload = await readBoundedRequestBodyString(
        request,
        maxBytes: largeRequestBodyBytes,
      );
      final Map<String, dynamic> body;
      try {
        body = jsonDecode(payload) as Map<String, dynamic>;
      } catch (e) {
        return jsonBadRequest({'error': 'Invalid JSON: $e'});
      }
      try {
        for (final entry in body.entries) {
          switch (entry.key) {
            case 'grindSetting':
              await grinder.setGrindSetting((entry.value as num).toInt());
            case 'feedingRpm':
              await grinder.setFeedingRpm((entry.value as num).toInt());
            case 'grindRpm':
              await grinder.setGrindRpm((entry.value as num).toInt());
            case 'brightness':
              await grinder.setBrightness((entry.value as num).toInt());
            case 'standbySec':
              await grinder.setStandbySec((entry.value as num).toInt());
            case 'cupDetect':
              await grinder.setCupDetect(entry.value as bool);
            case 'autoStop':
              await grinder.setAutoStop(entry.value as bool);
            case 'fastClean':
              await grinder.setFastClean(entry.value as bool);
          }
        }
      } catch (e) {
        return jsonError({'error': e.toString()});
      }
      return jsonOk(null);
    });

    app.put('/api/v1/grinder/<command>', (request, command) async {
      try {
        final grinder = _controller.connectedGrinder();
        switch (command) {
          case 'start':
            _log.fine("handling api grinder start");
            await grinder.start();
            return jsonOk(null);
          case 'stop':
            _log.fine("handling api grinder stop");
            await grinder.stop();
            return jsonOk(null);
          case 'preset':
            final payload = await readBoundedRequestBodyString(
              request,
              maxBytes: largeRequestBodyBytes,
            );
            final body = jsonDecode(payload) as Map<String, dynamic>;
            await grinder.setPreset(uid: body['uid'] as String?);
            return jsonOk(null);
          case 'grindSection':
            final payload = await readBoundedRequestBodyString(
              request,
              maxBytes: largeRequestBodyBytes,
            );
            final body = jsonDecode(payload) as Map<String, dynamic>;
            await grinder.setGrindSection(index: body['index'] as int?);
            return jsonOk(null);
          case 'querySections':
            await grinder.querySections();
            return jsonOk(null);
          case 'queryPresets':
            await grinder.queryPresets();
            return jsonOk(null);
          default:
            return jsonNotFound({'error': 'Unknown command: $command'});
        }
      } on DeviceNotConnectedException catch (e) {
        return jsonError({'error': e.toString()});
      }
    });

    app.get('/ws/v1/grinder/snapshot', admittedWebSocketHandler(_handleSnapshot));
  }

  Future<void> _handleSnapshot(
    WebSocketChannel socket,
    String? protocol,
  ) async {
    snapshotSub = _controller.grinderSnapshot.listen((snapshot) {
      socket.sink.add(jsonEncode(snapshot.toJson()));
    });
    socket.stream.listen(
      (msg) {},
      onDone: () => snapshotSub?.cancel(),
      onError: (e, _) => snapshotSub?.cancel(),
    );
  }
}
