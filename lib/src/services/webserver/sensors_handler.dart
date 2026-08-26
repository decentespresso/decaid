part of '../webserver_service.dart';

final class SensorsHandler {
  final SensorController _controller;
  final Logger _log = Logger("Sensor handler");

  SensorsHandler({required SensorController controller})
    : _controller = controller;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/sensors', (Request req) {
      final list = _controller.sensors.values.map((s) {
        final info = s.info;
        return {'id': s.deviceId, 'info': info.toJson()};
      }).toList();
      return jsonOk(list);
    });

    app.get('/api/v1/sensors/<id>', (Request req, String id) async {
      final sensor = _controller.sensors[id];
      if (sensor == null) {
        return jsonNotFound({'error': 'Sensor not found: $id'});
      }
      return jsonOk(sensor.info.toJson());
    });

    app.get('/ws/v1/sensors/<id>/snapshot', _handleSensorSnapshot);

    app.post('/api/v1/sensors/<id>/execute', (Request req, String id) async {
      final sensor = _controller.sensors[id];
      if (sensor == null) {
        return jsonNotFound({'error': 'Sensor not found: $id'});
      }

      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: smallRequestBodyBytes,
        timeout: smallRequestBodyTimeout,
      );
      final jsonBody = jsonDecode(body);
      final cmdId = jsonBody['commandId'] as String;
      final params = jsonBody['params'] as Map<String, dynamic>?;
      try {
        final res = await sensor.execute(cmdId, params);
        return jsonOk({'status': 'ok', 'result': res});
      } catch (e) {
        return jsonError({'status': 'error', 'message': e.toString()});
      }
    });
  }

  FutureOr<Response> _handleSensorSnapshot(Request req) {
    _log.info("Handling: $req");
    final id = req.params['id'];
    _log.info("got id: $id");
    return admittedWebSocketHandler((socket, protocol) {
      _log.info("upgraded to socket");
      final sensor = _controller.sensors[id];
      if (sensor == null) {
        socket.sink.add(jsonEncode({'error': 'not found'}));
        socket.sink.close();
        return;
      }

      Sensor? attached;
      StreamSubscription<dynamic>? dataSub;
      StreamSubscription<dynamic>? registrySub;
      StreamSubscription<dynamic>? socketSub;
      var disposed = false;

      void detach() {
        final sub = dataSub;
        dataSub = null;
        attached = null;
        sub?.cancel();
      }

      void dispose({bool closeSocket = false}) {
        if (disposed) return;
        disposed = true;
        registrySub?.cancel();
        registrySub = null;
        socketSub?.cancel();
        socketSub = null;
        detach();
        if (closeSocket) socket.sink.close();
      }

      void bind(Map<String, Sensor> registry) {
        final current = registry[id];
        if (identical(current, attached)) return;
        detach();
        if (current == null) return;
        attached = current;
        dataSub = current.data.listen((snapshot) {
          _log.finest("received snapshot: $snapshot");
          socket.sink.add(jsonEncode(snapshot));
        }, onError: (e, st) => log.severe('send error', e, st));
      }

      bind(_controller.sensors);
      registrySub = _controller.sensorRegistry.listen(
        bind,
        onDone: () => dispose(closeSocket: true),
        onError: (Object e, StackTrace st) {
          log.severe('sensor registry error', e, st);
          dispose(closeSocket: true);
        },
      );
      socketSub = socket.stream.listen(
        (msg) {},
        onDone: dispose,
        onError: (_, _) => dispose(),
      );
    })(req);
  }
}
